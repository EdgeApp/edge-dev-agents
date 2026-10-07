#!/usr/bin/env bash
# native-deps-hash.sh: the ONE definition of the native-build stamp value.
# Sourced by ios-rn-build.sh (writes the stamp, gates its cached-install path)
# and slot-preflight.sh (reads the stamp to print the build plan). Every reader
# and writer of .agent-native-build-stamp calls native_deps_hash; a second
# formula in any caller makes that caller report drift on every run.
#
# Usage: native_deps_hash [<repo-dir>]   (default: cwd). Prints 16 hex chars.
#
# MIGRATION WARNING: changing this hash's FORMAT invalidates every stamp in
# the fleet, and slots clone fresh from the MASTER each spawn — so without
# restamping the master sim's app container (and the standing pool clones),
# every run full-rebuilds forever, not once (the 2026-07-24 sonnet batch).
# After any format change: write the new hash to .agent-native-build-stamp in
# the master + pool sims' app data containers, computed from a CLEAN develop
# checkout (pod install rewrites the hermes-engine checksum, so a post-build
# dirty lock hashes differently than the pristine lock worktrees start with).
#
# Podfile.lock catches pod-level native drift. Webview bundle assets catch the
# OTHER native-embedded surface: edge-* packages ship built webview bundles
# under android/src/main/assets (embedded on iOS too), and a dep update
# (updot/pin swap) rewrites them WITHOUT touching Podfile.lock — a Metro JS
# reload can never refresh a native-embedded asset, so the cached fast path
# shipped a stale plugin webview on the 2026-07-22 swapter run. Hash both.
#
# pod install rewrites ONE line of the committed lock on every build (the
# hermes-engine SPEC CHECKSUM), so a stamp taken from the post-build file never
# matches the same worktree once the lock is restored, nor a clone's pristine
# checkout. podfile_lock_sum puts HEAD's hermes-engine checksum back before
# hashing; any other lock change (a pod added, a version moved) still changes
# the sum. Output is byte-identical to `shasum -a 256 ios/Podfile.lock` on a
# pristine lock, so existing stamps stay valid.
podfile_lock_sum() {
  local head_line
  head_line="$(git show HEAD:ios/Podfile.lock 2>/dev/null | grep -m1 -E '^  hermes-engine: [0-9a-f]{40}$' || true)"
  if [[ -n "$head_line" ]]; then
    sed -E "s/^  hermes-engine: [0-9a-f]{40}\$/$head_line/" ios/Podfile.lock
  else
    cat ios/Podfile.lock
  fi | shasum -a 256 | awk '{print $1 "  ios/Podfile.lock"}'
}
native_deps_hash() {
  (
    cd "${1:-.}" || exit 1
    {
      if [[ -f ios/Podfile.lock ]]; then podfile_lock_sum; else echo "no-podfile-lock"; fi
      for p in node_modules/edge-*/android/src/main/assets; do
        [[ -d "$p" ]] && find "$p" -name "*.js" -o -name "*.wasm"
      done | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null
    } | shasum -a 256 | cut -c1-16
  )
}
