#!/usr/bin/env bash
# native-deps-hash.sh: the ONE definition of the native-build stamp values.
# Sourced by ios-rn-build.sh (writes the stamps, gates its cached-install path),
# slot-preflight.sh (reads them to print the build plan) and native-app-cache.sh
# (keys stored builds on them). Every reader and writer of
# .agent-native-build-stamp calls native_deps_hash, and of
# .agent-native-module-stamp calls native_module_sources_hash; a second formula
# in any caller makes that caller report drift on every run.
#
# Usage: native_deps_hash [<repo-dir>]   (default: cwd). Prints 16 hex chars.
#        native_module_sources_hash [<repo-dir>]. Prints 64 hex chars.
#        native_module_stamp_check <app-data-dir> [<repo-dir>]. Prints one line.
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
# True when the lock's only uncommitted change is that same hermes-engine line:
# build output, not work. refresh-master-build.sh discards it instead of treating
# the checkout as dirty.
podfile_lock_only_hermes_changed() {
  local changed
  changed="$(git diff -U0 --no-color -- ios/Podfile.lock 2>/dev/null | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) ' || true)"
  [[ -n "$changed" ]] || return 1
  ! grep -qvE '^[-+]  hermes-engine: [0-9a-f]{40}$' <<<"$changed"
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

# native_module_sources_hash: one sha over the native files of each
# node_modules package that Podfile.lock takes a pod from by path. updot and
# hand edits rewrite that source at the same version, which leaves
# Podfile.lock (and so native_deps_hash) unchanged. Source files (Swift, ObjC,
# C/C++ and headers, podspecs) count by content; prebuilt static libraries
# (.a, .dylib) count by size, which a rebuild changes and which keeps a 100+ MB
# xcframework cheap. react-native's own pods are left out (thousands of files,
# and their only sanctioned edits go through patches/). It has its own stamp
# file: folding it into native_deps_hash would be a format change (see the
# MIGRATION WARNING above).
native_module_sources_hash() {
  (
    cd "${1:-.}" 2>/dev/null || exit 0
    local lock=ios/Podfile.lock pkg roots=()
    if [[ -f "$lock" ]]; then
      while IFS= read -r pkg; do
        [[ "$pkg" == react-native || ! -d "node_modules/$pkg" ]] && continue
        roots+=("node_modules/$pkg")
      done < <(grep -oE ':path: "?\.\./node_modules/(@[^/"]+/)?[^/"]+' "$lock" \
        | sed 's#.*\.\./node_modules/##' | LC_ALL=C sort -u)
    fi
    {
      [[ ${#roots[@]} -gt 0 ]] || exit 0
      find "${roots[@]}" -path '*/node_modules' -prune -o -type f \( -name '*.swift' \
        -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.c' -o -name '*.cc' \
        -o -name '*.cpp' -o -name '*.hpp' -o -name '*.podspec' \) -print0 2>/dev/null \
        | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null
      find "${roots[@]}" -path '*/node_modules' -prune -o -type f \( -name '*.a' \
        -o -name '*.dylib' \) -print0 2>/dev/null \
        | LC_ALL=C sort -z | xargs -0 stat -f 'size %z %N' 2>/dev/null
    } | shasum -a 256 | cut -c1-64
  )
}

# native_module_stamp_check <app-data-dir> [<repo-dir>]: compares the installed
# app's .agent-native-module-stamp with the tree. Prints `match`, `absent`
# (an app built before this stamp existed: callers trust native_deps_hash
# alone, and the next build or stored install writes the stamp), or
# `drift <have> <want>`.
native_module_stamp_check() {
  local have want
  have="$(tr -d '[:space:]' < "$1/.agent-native-module-stamp" 2>/dev/null || true)"
  [[ -n "$have" ]] || { echo absent; return 0; }
  want="$(native_module_sources_hash "${2:-.}")"
  if [[ "$have" == "$want" ]]; then echo match; else echo "drift ${have:0:12} ${want:0:12}"; fi
}
