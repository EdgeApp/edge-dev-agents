#!/usr/bin/env bash
# refresh-master-build.sh — Keep the master iOS sim's Edge.app build current with
# the develop branch, so pool clones (and the runs that use them) test against a
# fresh build instead of a stale one.
#
# WHY THIS EXISTS
#   Pool clones (agent-sim-pool-N) inherit the master sim's installed Edge.app via
#   APFS copy-on-write. The clones launch that app and bundle JS LIVE from the
#   slot's Metro (the JS is always fresh from the worktree), but the app's NATIVE
#   side (pods / native modules / new-arch) is baked into the master image at build
#   time and clones inherit it as-is. So a master "pinned" to an old develop costs:
#     1. dependency / non-GUI tasks (which never rebuild the GUI) test against an
#        old-develop native app, and
#     2. GUI tasks pay the slow full-rebuild more often, because the master's
#        native-build stamp (ios/Podfile.lock hash) rarely matches current develop.
#   Keeping the master built from current develop lets the common case (a task that
#   is JS-only relative to develop) FAST-PATH on the inherited app.
#
# WHAT IT DOES
#   Cheap check on every call: `git fetch` the develop ref and compare its SHA to a
#   marker of what the master was last built from. Then, in order:
#     - develop unchanged                       → no-op (fast).
#     - develop advanced, ios/Podfile.lock SAME → JS-only advance; the native app is
#       unchanged and clones bundle JS live anyway, so DON'T rebuild — just bump the
#       marker's develop SHA.
#     - develop advanced, ios/Podfile.lock CHANGED (or no marker yet / --force)
#                                               → rebuild from develop, install on the
#       master, re-stamp the marker, and mark every not-in_use pool slot `dirty` so
#       the caller (ensure-sim-pool.sh) reclones it from the fresh master.
#
#   It does NOT reclone the pool itself — it only marks slots dirty. ensure-sim-pool's
#   existing dirty→reclone loop does the recloning, so this stays DRY and the reclone
#   picks up the freshly-rebuilt master in the same pass.
#
# BLOCKING: the rebuild runs inline (the caller waits). A develop bump that changed
#   pods therefore stalls the spawn that noticed it (usually a few minutes; the
#   hermes-from-source worst case is guarded against in ios-rn-build.sh). This is the
#   operator's chosen tradeoff: runs get a fresh master before they provision.
#
# NON-FATAL: a fetch failure or a build failure does NOT block provisioning. It logs
#   loudly and exits 0 WITHOUT updating the marker, so the next tick retries while the
#   fleet keeps moving on the last-good master. A broken develop must never wedge the
#   whole fleet. (--strict makes a build failure exit 1 instead, for manual runs.)
#
# Usage:
#   refresh-master-build.sh [--repo <name>] [--bundle-id <id>] [--device <name>]
#                           [--runtime <substr>] [--develop-ref <ref>] [--port <n>]
#                           [--force] [--strict]
#
#   --repo         GUI repo to build (default: .watcher.default_repo from config).
#   --bundle-id    app bundle id to (re)install (default: co.edgesecure.app).
#   --device       master device name   (default: .watcher.master_sim.device).
#   --runtime      master runtime substr (default: .watcher.master_sim.runtime).
#   --develop-ref  ref to track (default: .watcher.master_sim.develop_ref or origin/develop).
#   --port         Metro port for the master build (default: $AGENT_MASTER_BUILD_PORT or 8280;
#                  kept out of the slot range 8181..818N).
#   --force        rebuild even if the marker says develop is unchanged.
#   --strict       exit 1 on build failure (default: non-fatal, exit 0).
#
# Disable entirely via config: .watcher.master_sim.refresh_on_develop = false, or the
# env SKIP_MASTER_REFRESH=1 (the new-machine import sets this so a just-imported build
# is not immediately rebuilt).
#
# Exit codes:
#   0 = master is current (or refresh skipped / non-fatally failed)
#   1 = a hard error (bad args, or build failed under --strict)

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
CONFIG="$DIR/asana-config.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"; mkdir -p "$STATE_DIR"
POOL="$STATE_DIR/pool.json"
POOL_LOCK="$DIR/pool.lock"
MARKER="$STATE_DIR/master-build.json"
BUILD_LOCK="$DIR/master-build.lock"
IOS_RN_BUILD="$HOME/.cursor/skills/build-and-test/scripts/ios-rn-build.sh"

REPO=""
BUNDLE_ID="co.edgesecure.app"
DEVICE=""
RUNTIME=""
DEVELOP_REF=""
PORT="${AGENT_MASTER_BUILD_PORT:-8280}"
FORCE=false
STRICT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO="$2";        shift 2 ;;
    --bundle-id)   BUNDLE_ID="$2";   shift 2 ;;
    --device)      DEVICE="$2";      shift 2 ;;
    --runtime)     RUNTIME="$2";     shift 2 ;;
    --develop-ref) DEVELOP_REF="$2"; shift 2 ;;
    --port)        PORT="$2";        shift 2 ;;
    --force)       FORCE=true;       shift ;;
    --strict)      STRICT=true;      shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { echo ">> refresh-master-build: $*" >&2; }

# Opt-out switches.
if [[ "${SKIP_MASTER_REFRESH:-}" == "1" ]]; then
  log "SKIP_MASTER_REFRESH=1 — skipping"; exit 0
fi
# NB: read the raw value — `jq '... // true'` would turn an explicit `false` back
# into `true` (jq's `//` treats false as empty). Absent/null => default ON.
if [[ "$(jq -r '.watcher.master_sim.refresh_on_develop' "$CONFIG" 2>/dev/null)" == "false" ]]; then
  log "config .watcher.master_sim.refresh_on_develop=false — skipping"; exit 0
fi

command -v xcrun >/dev/null 2>&1 || { log "xcrun not found (Xcode CLT) — skipping"; exit 0; }
[[ -x "$IOS_RN_BUILD" ]] || { log "ios-rn-build.sh not found at $IOS_RN_BUILD — skipping"; exit 0; }

# Resolve config-backed defaults.
[[ -n "$REPO"        ]] || REPO="$(jq -r '.watcher.default_repo // "edge-react-gui"' "$CONFIG")"
[[ -n "$DEVICE"      ]] || DEVICE="$(jq -r '.watcher.master_sim.device // "iPhone 16 Pro Max"' "$CONFIG")"
[[ -n "$RUNTIME"     ]] || RUNTIME="$(jq -r '.watcher.master_sim.runtime // "iOS 18"' "$CONFIG")"
[[ -n "$DEVELOP_REF" ]] || DEVELOP_REF="$(jq -r '.watcher.master_sim.develop_ref // "origin/develop"' "$CONFIG")"
REPOS_ROOT="$(jq -r '.watcher.repos_root // "~/git"' "$CONFIG")"; REPOS_ROOT="${REPOS_ROOT/#\~/$HOME}"
REPO_DIR="$REPOS_ROOT/$REPO"

[[ -d "$REPO_DIR/.git" ]] || { log "repo checkout not found at $REPO_DIR — skipping"; exit 0; }

# Resolve the master UDID (the named device, NOT an agent-sim-* clone).
master_udid() {
  xcrun simctl list devices available 2>/dev/null \
    | sed -n "/^-- $RUNTIME/,/^-- /p" \
    | grep -F "$DEVICE (" | grep -viE "agent-sim" | head -1 \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true
}
MASTER="$(master_udid)"
[[ -n "$MASTER" ]] || { log "no master sim ('$DEVICE' / '$RUNTIME') found — skipping"; exit 0; }

# Cheap check: fetch develop and read its SHA. A fetch failure is non-fatal.
REMOTE="${DEVELOP_REF%%/*}"; BRANCH="${DEVELOP_REF#*/}"
if ! git -C "$REPO_DIR" fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null; then
  log "git fetch $DEVELOP_REF failed (offline?) — proceeding on current master (non-fatal)"; exit 0
fi
TARGET_SHA="$(git -C "$REPO_DIR" rev-parse "$DEVELOP_REF" 2>/dev/null || true)"
[[ -n "$TARGET_SHA" ]] || { log "could not resolve $DEVELOP_REF — skipping (non-fatal)"; exit 0; }

# Marker readers (missing marker => empty strings => rebuild).
marker_get() { [[ -f "$MARKER" ]] && jq -r "$1 // empty" "$MARKER" 2>/dev/null || true; }
HAVE_SHA="$(marker_get '.develop_sha')"
HAVE_PODHASH="$(marker_get '.podfile_lock_hash')"
HAVE_UDID="$(marker_get '.master_udid')"

# Fast no-op: marker matches current develop AND the same master sim AND the master
# still has the app installed. (--force overrides.)
if ! $FORCE && [[ "$HAVE_SHA" == "$TARGET_SHA" && "$HAVE_UDID" == "$MASTER" ]]; then
  log "master up to date with $DEVELOP_REF (${TARGET_SHA:0:9}) — no-op"; exit 0
fi

# Native-change probe straight from the ref (no working-tree mutation yet). Matches
# ios-rn-build.sh's native_deps_hash (shasum -a 256 of ios/Podfile.lock, first 16).
TARGET_PODHASH="$(git -C "$REPO_DIR" show "$DEVELOP_REF:ios/Podfile.lock" 2>/dev/null | shasum -a 256 | cut -c1-16 || true)"
[[ -n "$TARGET_PODHASH" ]] || TARGET_PODHASH="no-podfile-lock"

write_marker() {
  local tmp; tmp="$(mktemp)"
  jq -n --arg sha "$TARGET_SHA" --arg ph "$TARGET_PODHASH" --arg u "$MASTER" --arg ref "$DEVELOP_REF" \
    '{develop_sha:$sha, podfile_lock_hash:$ph, master_udid:$u, develop_ref:$ref}' > "$tmp" && mv "$tmp" "$MARKER"
}

# JS-only develop advance: native app unchanged, clones bundle JS live → no rebuild.
# Only valid when we already have a built master (marker present with a pod hash).
if ! $FORCE && [[ -n "$HAVE_PODHASH" && "$HAVE_PODHASH" == "$TARGET_PODHASH" && "$HAVE_UDID" == "$MASTER" ]]; then
  log "develop advanced to ${TARGET_SHA:0:9} but ios/Podfile.lock is unchanged (JS-only) — no rebuild; bumping marker"
  write_marker
  exit 0
fi

# ── Rebuild path ────────────────────────────────────────────────────────────────
# Serialize: only one rebuild at a time even if two callers race. macOS has no
# `flock`, so use a noclobber lockfile (the pattern the pool scripts use). Reap a
# stale lock from a crashed build so a refresh is never wedged forever. One EXIT
# trap removes BOTH locks (the pool-marking step below also takes pool.lock).
if [[ -f "$BUILD_LOCK" ]]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$BUILD_LOCK" 2>/dev/null || echo 0) ))
  [[ "$AGE" -gt 3600 ]] && { log "stale build lock (${AGE}s) — reclaiming"; rm -f "$BUILD_LOCK"; }
fi
if ! ( set -C; : > "$BUILD_LOCK" ) 2>/dev/null; then
  log "another refresh holds the build lock — skipping (it will leave the master current)"; exit 0
fi
trap 'rm -f "$BUILD_LOCK" "$POOL_LOCK"' EXIT
# Re-read the marker after acquiring the lock: a racing caller may have just finished.
HAVE_SHA="$(marker_get '.develop_sha')"; HAVE_UDID="$(marker_get '.master_udid')"
if ! $FORCE && [[ "$HAVE_SHA" == "$TARGET_SHA" && "$HAVE_UDID" == "$MASTER" ]]; then
  log "master became current while waiting for the lock — no-op"; exit 0
fi

build_failed() {
  log "FAIL — $1"
  log "leaving marker stale so the next tick retries; provisioning continues on the last-good master"
  $STRICT && exit 1 || exit 0
}

# 1. Put the main checkout exactly on develop. Refuse if it has uncommitted work —
#    never reset a dirty operator checkout. (Agent work lives in worktrees, not here.)
if [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]]; then
  log "WARN — $REPO_DIR has uncommitted changes; refusing to reset it. Skipping refresh (non-fatal)."
  exit 0
fi
log "checking out $DEVELOP_REF in $REPO_DIR (${TARGET_SHA:0:9})"
git -C "$REPO_DIR" checkout --quiet "$BRANCH" 2>/dev/null || git -C "$REPO_DIR" checkout --quiet -B "$BRANCH" "$DEVELOP_REF"
git -C "$REPO_DIR" reset --hard --quiet "$DEVELOP_REF" || build_failed "could not reset $REPO_DIR to $DEVELOP_REF"

# 2. Boot the master so ios-rn-build can install onto it.
log "booting master $MASTER"
xcrun simctl boot "$MASTER" >/dev/null 2>&1 || true
if ! xcrun simctl bootstatus "$MASTER" -b >/dev/null 2>&1; then
  build_failed "master $MASTER did not reach booted state"
fi

# 3. Build develop and install it on the master. --force-rebuild guarantees a clean
#    develop image (and re-stamps the in-app native hash that clones inherit).
log "building $REPO @ ${TARGET_SHA:0:9} and installing on master (port $PORT) — this can take several minutes"
if ( cd "$REPO_DIR" && "$IOS_RN_BUILD" --udid "$MASTER" --bundle-id "$BUNDLE_ID" --port "$PORT" --force-rebuild ); then
  log "master build + install OK"
else
  build_failed "ios-rn-build failed for $REPO @ ${TARGET_SHA:0:9}"
fi

# 4. Shut the master down so clone-ios-sim clones from a Shutdown source (data
#    persists across shutdown; clones inherit the freshly-installed app via APFS).
xcrun simctl shutdown "$MASTER" >/dev/null 2>&1 || true

# 5. Record what we built.
write_marker
log "marker updated: develop=${TARGET_SHA:0:9} pods=$TARGET_PODHASH master=$MASTER"

# 6. Mark every not-in_use pool slot dirty so ensure-sim-pool reclones it from the
#    fresh master. (in_use slots belong to a live run and are never touched.)
if [[ -f "$POOL" ]]; then
  i=0
  while ! ( set -C; : > "$POOL_LOCK" ) 2>/dev/null; do
    i=$((i + 1)); [[ $i -gt 300 ]] && { log "WARN — could not lock pool to mark slots dirty; ensure-sim-pool will refresh later"; exit 0; }
    sleep 0.1
  done
  # (EXIT trap set above already removes POOL_LOCK; just drop it after the write too.)
  NEW="$(jq '(.pool[] | select(.state != "in_use") | .state) = "dirty"' "$POOL")"
  tmp="$(mktemp)"; jq . <<<"$NEW" > "$tmp" && mv "$tmp" "$POOL"
  rm -f "$POOL_LOCK"
  N="$(jq '[.pool[] | select(.state == "dirty")] | length' "$POOL")"
  log "marked $N not-in_use pool slot(s) dirty → ensure-sim-pool will reclone from the fresh master"
fi

exit 0
