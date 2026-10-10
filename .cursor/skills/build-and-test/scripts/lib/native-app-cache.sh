#!/usr/bin/env bash
# native-app-cache.sh: built Debug .app bundles kept by the native state they were
# built from, so a worktree whose native state was already built somewhere gets
# that app installed in seconds instead of a 12-15 minute cold compile.
# Sourced by ios-rn-build.sh (installs on a hit, stores after a fresh build) and
# slot-preflight.sh (plans an install when a hit is waiting). Needs
# lib/native-deps-hash.sh sourced first.
#
# WHY A HIT IS SAFE: a Debug app carries only native code and native-embedded
# assets; its JS comes live from the slot's Metro. Two trees with the same
# native inputs therefore build interchangeable apps, whatever their JS differs
# in. The stamp alone (native_deps_hash: Podfile.lock + edge-* webview assets)
# cannot say that, because it does not see native SOURCE. So the key adds what
# the stamp lacks, and a tree the key cannot describe gets no key at all:
#   - the committed tree of ios/ (app target sources, Podfile, project file);
#   - the committed tree of patches/ (patch-package rewrites native modules
#     without touching Podfile.lock);
#   - no key when either holds an uncommitted change. A build of such a tree
#     must not be stored (another run would receive those edits), and such a
#     tree must not take a stored app (it would lose its own edits).
# ios/Podfile.lock is exempt from the dirty check: every build rewrites its
# hermes-engine line, and its content is already in the key through the stamp.
#
# WHAT A MISS LOOKS LIKE: native state nobody built yet (a PR that moves a pod,
# a dependency linked in from a sibling worktree), or a dirty native tree. Those
# take the full build exactly as before.
#
# Layout: $NATIVE_APP_CACHE_DIR/<bundle-id>/<key>/<Name>.app plus a `built-from`
# note. Entries are APFS clones of the installed bundle (about 330 MB logical,
# near zero on disk until the source goes away). The newest
# NATIVE_APP_CACHE_KEEP entries per bundle id are kept, by last use.

NATIVE_APP_CACHE_DIR="${NATIVE_APP_CACHE_DIR:-$HOME/Library/Caches/agent-native-apps}"
NATIVE_APP_CACHE_KEEP="${NATIVE_APP_CACHE_KEEP:-8}"

# native_app_cache_key [<repo-dir>]: prints the key, or nothing when this tree
# may neither store nor take a cached app.
native_app_cache_key() {
  (
    cd "${1:-.}" 2>/dev/null || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    [[ -d ios ]] || exit 0
    local dirty stamp ios_tree patches_tree
    dirty="$(git status --porcelain --untracked-files=all -- ios patches 2>/dev/null \
      | grep -v -E '^.. ios/Podfile\.lock$' | head -1)"
    [[ -z "$dirty" ]] || exit 0
    stamp="$(native_deps_hash .)"
    ios_tree="$(git rev-parse -q --verify 'HEAD:ios' 2>/dev/null || true)"
    patches_tree="$(git rev-parse -q --verify 'HEAD:patches' 2>/dev/null || echo none)"
    [[ -n "$stamp" && -n "$ios_tree" ]] || exit 0
    printf '%s-%s\n' "$stamp" "$(printf '%s %s' "$ios_tree" "$patches_tree" | shasum -a 256 | cut -c1-12)"
  )
}

# native_app_cache_get <bundle-id> <key>: prints the cached .app path and marks
# the entry used; prints nothing on a miss.
native_app_cache_get() {
  local dir="$NATIVE_APP_CACHE_DIR/$1/$2" app
  [[ -n "${2:-}" && -d "$dir" ]] || return 0
  app="$(find "$dir" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
  [[ -n "$app" && -f "$app/Info.plist" ]] || return 0
  touch "$dir" 2>/dev/null || true
  printf '%s\n' "$app"
}

# native_app_cache_put <bundle-id> <key> <app-bundle> [<note>]: stores a copy of
# the bundle under the key (an existing entry is replaced), then trims the cache.
# Built beside the final path and moved into place, so a reader never sees a
# half-copied bundle. Returns 1 when nothing was stored.
native_app_cache_put() {
  local bundle_id="$1" key="$2" app="$3" note="${4:-}" base dir tmp
  [[ -n "$key" && -d "$app" && -f "$app/Info.plist" ]] || return 1
  base="$NATIVE_APP_CACHE_DIR/$bundle_id"
  dir="$base/$key"
  tmp="$base/.tmp-$key-$$"
  mkdir -p "$tmp" || return 1
  if ! { cp -c -R "$app" "$tmp/" 2>/dev/null || cp -R "$app" "$tmp/"; }; then
    rm -rf "$tmp"; return 1
  fi
  printf '%s\n' "$note" > "$tmp/built-from"
  rm -rf "$dir"
  mv "$tmp" "$dir" || { rm -rf "$tmp"; return 1; }
  native_app_cache_trim "$bundle_id"
}

# native_app_cache_trim <bundle-id>: keep the NATIVE_APP_CACHE_KEEP most recently
# used entries; also clears temp folders a killed put left behind (over an hour old).
native_app_cache_trim() {
  local base="$NATIVE_APP_CACHE_DIR/$1" n=0 d
  [[ -d "$base" ]] || return 0
  find "$base" -maxdepth 1 -name '.tmp-*' -type d -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    n=$((n + 1))
    [[ "$n" -le "$NATIVE_APP_CACHE_KEEP" ]] || rm -rf "$base/$d"
  done < <(cd "$base" && ls -t 2>/dev/null)
}
