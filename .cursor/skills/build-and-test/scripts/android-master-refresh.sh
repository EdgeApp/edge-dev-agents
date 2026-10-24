#!/usr/bin/env bash
# android-master-refresh.sh — Update the master Android AVD (edge-android-master)
# and re-save its `default_boot` snapshot, the image every slot's -read-only
# emulator loads (android-emulator.sh).
#
# Boots the master read-write, optionally installs a debug APK and re-seeds the
# Edge accounts from the iOS master sim, applies the guest network setting
# below, stops the app, saves the snapshot and shuts the master down. Slots
# cannot run during this: read-only instances read the master's files, so the
# script refuses while any instance of the AVD is up.
#
# Seeding copies the iOS master's Edge disk (Documents/{logins,repos,local})
# into the app's `files/` dir, which is where edge-core keeps the same tree on
# Android. The tar is built with COPYFILE_DISABLE=1: macOS tar otherwise adds
# AppleDouble `._*` sidecars, which edge-core reads as sync changes and fails
# on ("Unexpected token" alert, "Could not sync").
#
# Guest setting baked into the snapshot: net.ipv4.tcp_syn_retries=2 (connects
# to a dead host give up in ~7s, not ~2min). Plugins that race several nodes
# and never abort the loser (dead Tron nodes on :8090) otherwise pin OkHttp's
# connection slots, and the app's other requests queue behind them.
#
# AVD (create once with avdmanager, android-36 google_apis arm64, pixel_7):
#   hw.ramSize=8192 hw.cpu.ncore=6 disk.dataPartition.size=32G vm.heapSize=576M
#   hw.keyboard=yes hw.gpu.enabled=yes hw.gpu.mode=host
#
# Usage:
#   android-master-refresh.sh [--apk <debug.apk>] [--seed] [--ios-master <udid>] [--avd <name>]
#
#   --apk:        `adb install -r` this debug APK first (debug-keystore signed, so
#                 app data survives). Required on a fresh AVD: run-as needs it.
#   --seed:       replace the app's logins/repos/local with the iOS master's.
#   --ios-master: iOS master UDID (default: the named master from
#                 asana-config.json .watcher.master_sim, as refresh-master-build.sh).
#
# Output: one line per step (`APK:`, `SEED: <n> logins`, `SNAPSHOT: default_boot`).
# Exit codes: 0 = snapshot saved; 1 = error (instance running, boot timeout,
#             app not installed, seed or snapshot failed).

set -euo pipefail

AVD="edge-android-master"; APK=""; SEED=false; IOS_MASTER=""; PKG="co.edgesecure.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apk)        APK="$2";        shift 2 ;;
    --seed)       SEED=true;       shift ;;
    --ios-master) IOS_MASTER="$2"; shift 2 ;;
    --avd)        AVD="$2";        shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"; [[ -x "$ADB" ]] || ADB="$(command -v adb)"
EMU="$SDK/emulator/emulator"
PORT=5698; SERIAL="emulator-$PORT"
adb() { "$ADB" -s "$SERIAL" "$@"; }

for s in $("$ADB" devices | awk '/^emulator-/{print $1}'); do
  [[ "$("$ADB" -s "$s" emu avd name 2>/dev/null | head -1 | tr -d '\r')" == "$AVD" ]] \
    && { echo "$s runs $AVD; stop every instance first (android-emulator.sh stop --serial $s)" >&2; exit 1; }
done

LOG="/tmp/android-master-refresh.log"
nohup "$EMU" -avd "$AVD" -no-window -no-audio -no-boot-anim -gpu host -port "$PORT" >"$LOG" 2>&1 &
PID=$!
# Any failure from here on shuts the master down, so slots can start again.
trap '"$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true' EXIT
T0=$SECONDS
until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do
  kill -0 "$PID" 2>/dev/null || { echo "master emulator exited; see $LOG" >&2; exit 1; }
  (( SECONDS - T0 < 240 )) || { echo "master not booted after 240s; see $LOG" >&2; exit 1; }
  sleep 2
done

if [[ -n "$APK" ]]; then
  adb install -r "$APK" >/dev/null
  echo "APK: $APK"
fi
adb shell pm path "$PKG" >/dev/null 2>&1 || { echo "$PKG not installed on the master; pass --apk" >&2; exit 1; }

if [[ "$SEED" == true ]]; then
  if [[ -z "$IOS_MASTER" ]]; then
    CONFIG="$HOME/.config/agent-watcher/asana-config.json"
    DEVICE="$(jq -r '.watcher.master_sim.device // "iPhone 16 Pro Max"' "$CONFIG")"
    RUNTIME="$(jq -r '.watcher.master_sim.runtime // "iOS 18"' "$CONFIG")"
    IOS_MASTER="$(xcrun simctl list devices available | sed -n "/^-- $RUNTIME/,/^-- /p" \
      | grep -F "$DEVICE (" | grep -viE 'agent-sim' | head -1 \
      | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)"
    [[ -n "$IOS_MASTER" ]] || { echo "no iOS master ('$DEVICE' / '$RUNTIME'); pass --ios-master" >&2; exit 1; }
  fi
  # simctl get_app_container needs a booted sim; read the container metadata instead.
  DOCS=""
  for c in "$HOME/Library/Developer/CoreSimulator/Devices/$IOS_MASTER/data/Containers/Data/Application"/*; do
    [[ "$(plutil -extract MCMMetadataIdentifier raw "$c/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null)" == "$PKG" ]] \
      && { DOCS="$c/Documents"; break; }
  done
  [[ -d "$DOCS/logins" ]] || { echo "no Edge logins under $DOCS" >&2; exit 1; }
  TAR="$(mktemp -t edge-seed).tar"
  COPYFILE_DISABLE=1 tar -C "$DOCS" -cf "$TAR" logins repos local
  adb shell am force-stop "$PKG"
  adb push "$TAR" /data/local/tmp/edge-seed.tar >/dev/null 2>&1
  rm -f "$TAR"
  adb shell "chmod 644 /data/local/tmp/edge-seed.tar; run-as $PKG sh -c 'cd files && rm -rf logins repos local && tar -xf /data/local/tmp/edge-seed.tar'"
  adb shell rm /data/local/tmp/edge-seed.tar
  [[ "$(adb shell "run-as $PKG sh -c 'find files -name \"._*\" | wc -l'" | tr -d '\r ')" == 0 ]] \
    || { echo "AppleDouble files landed in files/" >&2; exit 1; }
  echo "SEED: $(adb shell "run-as $PKG sh -c 'ls files/logins | wc -l'" | tr -d '\r ') logins"
fi

adb root >/dev/null; adb wait-for-device
adb shell sysctl -w net.ipv4.tcp_syn_retries=2 >/dev/null
adb shell am force-stop "$PKG"
adb emu avd snapshot save default_boot | grep -q '^OK' || { echo "snapshot save failed" >&2; exit 1; }
echo "SNAPSHOT: default_boot"
