#!/usr/bin/env bash
# android-emulator.sh — Start or stop a slot's Android emulator: a -read-only
# instance of the one master AVD (edge-android-master).
#
# The master holds the debug app with the roster accounts seeded and a
# `default_boot` quickboot snapshot (android-master-refresh.sh builds both).
# -read-only lets every slot run the same AVD at once: each instance loads the
# snapshot (~2s) and writes into a temp overlay that is discarded when it
# exits. Nothing a slot does (APK install, logins, sync data) reaches the
# master or another slot, and a restarted slot comes back as the master. So
# after any start, reinstall the slot's APK if it needs one, then run
# android-dev-server.sh.
#
# Usage:
#   android-emulator.sh start [--port <even-port>] [--avd edge-android-master]
#   android-emulator.sh stop  --serial <emulator-NNNN>
#
#   --port: console port; the adb serial is emulator-<port>. Default derives from
#           the slot's Metro port: 5700 + 2 * ($AGENT_METRO_PORT - 8181), so slot
#           N gets 5700+2N, clear of the emulator's 5554.. default range.
#
# Output: start prints `EMULATOR: emulator-<port> pid <pid> booted <secs>s`;
#         stop prints `STOPPED: <serial>`.
# Exit codes: 0 = ok; 1 = error (serial already in use, boot timeout, bad args).

set -euo pipefail

CMD="${1:-}"; shift || true
PORT=""; SERIAL=""; AVD="edge-android-master"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)   PORT="$2";   shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --avd)    AVD="$2";    shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"; [[ -x "$ADB" ]] || ADB="$(command -v adb)"
EMU="$SDK/emulator/emulator"
[[ -x "$EMU" ]] || { echo "emulator not found under $SDK/emulator" >&2; exit 1; }

case "$CMD" in
  start)
    if [[ -z "$PORT" ]]; then
      [[ -n "${AGENT_METRO_PORT:-}" ]] || { echo "pass --port or set AGENT_METRO_PORT" >&2; exit 1; }
      PORT=$(( 5700 + 2 * (AGENT_METRO_PORT - 8181) ))
    fi
    (( PORT % 2 == 0 )) || { echo "--port must be even: $PORT" >&2; exit 1; }
    SERIAL="emulator-$PORT"
    "$ADB" devices | grep -q "^$SERIAL[[:space:]]" \
      && { echo "$SERIAL is already running (another slot, or a leftover: stop it by serial)" >&2; exit 1; }
    LOG="/tmp/android-emulator-$PORT.log"
    nohup "$EMU" -avd "$AVD" -read-only -no-window -no-audio -no-boot-anim -gpu host -port "$PORT" >"$LOG" 2>&1 &
    PID=$!
    T0=$SECONDS
    until [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do
      kill -0 "$PID" 2>/dev/null || { echo "emulator exited; see $LOG" >&2; tail -5 "$LOG" >&2; exit 1; }
      (( SECONDS - T0 < 180 )) || { echo "$SERIAL not booted after 180s; see $LOG" >&2; exit 1; }
      sleep 2
    done
    grep -q "Successfully loaded snapshot 'default_boot'" "$LOG" \
      || echo "android-emulator: cold boot (no default_boot snapshot); run android-master-refresh.sh" >&2
    echo "EMULATOR: $SERIAL pid $PID booted $(( SECONDS - T0 ))s"
    ;;
  stop)
    [[ -n "$SERIAL" ]] || { echo "stop needs --serial" >&2; exit 1; }
    "$ADB" -s "$SERIAL" emu kill >/dev/null
    echo "STOPPED: $SERIAL"
    ;;
  *) echo "usage: android-emulator.sh start [--port <p>] | stop --serial <s>" >&2; exit 1 ;;
esac
