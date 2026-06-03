#!/usr/bin/env bash
# export-sim-accounts.sh — Snapshot the logged-in Edge accounts from this machine's
# master iPhone 16 Pro Max simulator into a self-applying tarball for another machine.
#
# Captures: the Edge.app, the account data (Documents/{logins,repos,local}), and the
# device keychain. SKIPS the multi-GB Zcash/Pirate shielded-sync caches — those re-sync
# from the network after login, so there's no reason to ship them.
#
# The tarball embeds an IMPORT.sh that, on the destination, finds that machine's
# iPhone 16 Pro Max sim, installs Edge, and replaces its account data + keychain — so
# pool clones of that master inherit the logged-in accounts.
#
# Usage: export-sim-accounts.sh [device-name] [out.tgz]
set -euo pipefail
DEVICE_NAME="${1:-iPhone 16 Pro Max}"
OUT="${2:-$HOME/Downloads/edge-sim-accounts.tgz}"
BUNDLE_ID="co.edgesecure.app"

# Resolve the master sim (the one named "<device>", not the agent-sim-* pool clones).
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | grep -viE "agent-sim" | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "No '$DEVICE_NAME' sim found" >&2; exit 1; }
DEV="$HOME/Library/Developer/CoreSimulator/Devices/$UDID"
echo ">> master sim: $UDID"

# Active Edge data container = the co.edgesecure.app container whose logins were touched most recently.
best=""; best_t=0
for m in "$DEV"/data/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist; do
  [ -f "$m" ] || continue
  [ "$(plutil -extract MCMMetadataIdentifier raw "$m" 2>/dev/null)" = "$BUNDLE_ID" ] || continue
  c=$(dirname "$m"); lf=$(ls -t "$c"/Documents/logins/* 2>/dev/null | head -1); [ -n "$lf" ] || continue
  t=$(stat -f %m "$lf"); [ "$t" -gt "$best_t" ] && { best_t=$t; best="$c"; }
done
[ -n "$best" ] || { echo "No Edge container with logins found (is Edge logged in on the master?)" >&2; exit 1; }
echo ">> active Edge data container: $best"

# Active Edge.app = the newest co.edgesecure.app bundle.
app=""; app_t=0
for a in "$DEV"/data/Containers/Bundle/Application/*/*.app; do
  [ -d "$a" ] || continue
  [ "$(plutil -extract CFBundleIdentifier raw "$a/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] || continue
  t=$(stat -f %m "$a"); [ "$t" -gt "$app_t" ] && { app_t=$t; app="$a"; }
done
[ -n "$app" ] || { echo "No Edge.app bundle found" >&2; exit 1; }
echo ">> Edge.app: $app"

STAGE=$(mktemp -d)
mkdir -p "$STAGE/account/Documents" "$STAGE/app"
cp -R "$app" "$STAGE/app/"
for sub in logins repos local; do [ -d "$best/Documents/$sub" ] && cp -R "$best/Documents/$sub" "$STAGE/account/Documents/$sub"; done
cp -R "$DEV"/data/Library/Keychains "$STAGE/keychains"

cat > "$STAGE/IMPORT.sh" <<'IMPORT'
#!/usr/bin/env bash
# Self-contained Edge sim-account import. Standalone usage on the new mac:
#   mkdir -p /tmp/ea && tar xzf ~/Downloads/edge-sim-accounts.tgz -C /tmp/ea && /tmp/ea/IMPORT.sh
# Finds this machine's iPhone 16 Pro Max sim, installs Edge, drops in the logged-in
# accounts + keychain, and (if the orchestration is installed) refreshes the sim pool.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEVICE_NAME="${1:-iPhone 16 Pro Max}"
BUNDLE_ID="co.edgesecure.app"
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | grep -viE "agent-sim" | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "No '$DEVICE_NAME' sim on this machine" >&2; exit 1; }
DEV="$HOME/Library/Developer/CoreSimulator/Devices/$UDID"
echo ">> dest master sim: $UDID"
APP=$(ls -d "$HERE"/app/*.app | head -1)
xcrun simctl boot "$UDID" 2>/dev/null || true
sleep 5
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>/dev/null || true   # first launch creates the data container
sleep 6
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
CONT=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
[ -d "$CONT" ] || { echo "Could not resolve Edge data container after install" >&2; exit 1; }
echo ">> dest Edge container: $CONT"
xcrun simctl shutdown "$UDID" 2>/dev/null || true
sleep 2
mkdir -p "$CONT/Documents"
for sub in logins repos local; do
  [ -d "$HERE/account/Documents/$sub" ] || continue
  rm -rf "$CONT/Documents/$sub"; cp -R "$HERE/account/Documents/$sub" "$CONT/Documents/$sub"
done
[ -d "$HERE/keychains" ] && { rm -rf "$DEV/data/Library/Keychains"; cp -R "$HERE/keychains" "$DEV/data/Library/Keychains"; }
echo ">> accounts imported into the master sim ($UDID)."
if [ -x "$HOME/.config/agent-watcher/ensure-sim-pool.sh" ]; then
  echo ">> refreshing the sim pool so clones inherit the logged-in master (~minutes)..."
  rm -f "$HOME/.config/agent-watcher/pool.json"
  "$HOME/.config/agent-watcher/ensure-sim-pool.sh" --size 2 || echo ">> (pool refresh failed; rerun it later)"
else
  echo ">> (orchestration not installed here — skipped pool refresh)"
fi
echo ">> DONE. Boot the sim + open Edge: accounts present. If PIN login fails, password-login once (accounts are there); the YOLO BTC account auto-logs in."
IMPORT
chmod +x "$STAGE/IMPORT.sh"

tar --disable-copyfile -czf "$OUT" -C "$STAGE" .
chmod 600 "$OUT"
rm -rf "$STAGE"
echo ">> exported $(du -sh "$OUT" | awk '{print $1}') → $OUT"
