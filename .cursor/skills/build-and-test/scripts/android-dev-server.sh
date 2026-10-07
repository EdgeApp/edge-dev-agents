#!/usr/bin/env bash
# android-dev-server.sh — Point a debug app on ONE Android emulator at this slot's
# Metro port, then relaunch it.
#
# An RN debug build on an emulator defaults to 10.0.2.2:8081 (host loopback) and
# ignores `adb reverse`. A host-side 127.0.0.1:8081 forwarder is a single
# host-global port: with two emulators running, both apps load whichever slot's
# Metro the forwarder points at. Instead this writes RN's per-app `debug_http_host`
# SharedPreference (PackagerConnectionSettings) to 10.0.2.2:<port> inside the
# app's own data dir, so each emulator reaches its own slot's Metro and nothing
# listens on 8081.
#
# Usage:
#   android-dev-server.sh --serial <emulator-NNNN> --port <metro-port> [--package co.edgesecure.app] [--no-launch]
#
#   --serial:    adb serial of the emulator (`adb devices`). Required: never rely
#                on adb's single-device default when other slots run emulators.
#   --port:      the slot's Metro port ($AGENT_METRO_PORT).
#   --package:   application id (default co.edgesecure.app).
#   --no-launch: write the setting and leave the app stopped.
#
# The app must be installed and debuggable (`run-as` needs a debug APK). The
# setting persists across relaunches and reinstalls with `adb install -r`; a
# fresh install or `pm clear` wipes it, so re-run after those.
#
# Output: one `DEV_SERVER: <serial> <package> 10.0.2.2:<port>` line on stdout.
# Exit codes: 0 = written (and launched); 1 = error (adb/run-as failed, bad args).

set -euo pipefail

SERIAL=""
PORT=""
PKG="co.edgesecure.app"
LAUNCH=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)    SERIAL="$2"; shift 2 ;;
    --port)      PORT="$2";   shift 2 ;;
    --package)   PKG="$2";    shift 2 ;;
    --no-launch) LAUNCH=false; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$SERIAL" && -n "$PORT" ]] || { echo "usage: android-dev-server.sh --serial <emulator-NNNN> --port <metro-port>" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "--port must be numeric: $PORT" >&2; exit 1; }

ADB="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}/platform-tools/adb"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"
[[ -n "$ADB" ]] || { echo "adb not found (set ANDROID_HOME)" >&2; exit 1; }
adb() { "$ADB" -s "$SERIAL" "$@"; }

HOST="10.0.2.2:$PORT"
PREFS="/data/data/$PKG/shared_prefs/${PKG}_preferences.xml"

# Stop first: a running app holds the prefs in memory and rewrites the file.
adb shell am force-stop "$PKG"
adb shell run-as "$PKG" mkdir -p "/data/data/$PKG/shared_prefs"
# Merge into an existing prefs file so other dev settings survive; create it otherwise.
CUR=$(adb shell run-as "$PKG" cat "$PREFS" 2>/dev/null | tr -d '\r' || true)
if printf '%s' "$CUR" | grep -q '<map'; then
  NEW=$(printf '%s\n' "$CUR" \
    | grep -v 'name="debug_http_host"' \
    | sed "s|</map>|    <string name=\"debug_http_host\">$HOST</string>\n</map>|; s|<map />|<map>\n    <string name=\"debug_http_host\">$HOST</string>\n</map>|")
else
  NEW="<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name=\"debug_http_host\">$HOST</string>
</map>"
fi
# adb shell re-joins its argv into one remote command line, so the redirect must
# be quoted for the device shell or it runs outside run-as.
printf '%s\n' "$NEW" | adb shell "run-as $PKG sh -c 'cat > $PREFS'"
adb shell run-as "$PKG" cat "$PREFS" | grep -q "<string name=\"debug_http_host\">$HOST</string>" \
  || { echo "android-dev-server: debug_http_host not readable back from $PREFS" >&2; exit 1; }

if [[ "$LAUNCH" == true ]]; then
  ACT=$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" | tr -d '\r' | tail -1)
  adb shell am start -n "$ACT" 2>&1 | grep -q '^Error' \
    && { echo "android-dev-server: launch of $ACT failed" >&2; exit 1; }
fi
echo "DEV_SERVER: $SERIAL $PKG $HOST"
