#!/usr/bin/env bash
# derived-data-reap.sh — Delete Xcode DerivedData folders by the workspace they built.
#
# Xcode names each ~/Library/Developer/Xcode/DerivedData/<Name>-<hash>/ folder after
# the workspace PATH and records that path in the folder's info.plist (WorkspacePath).
# Every agent worktree is a new path, so every worktree that ran `run-ios` leaves a
# ~2 GB folder behind that nothing else removes. ios-rn-build.sh's xcodebuild fallback
# builds into ios-rn-build-<hash>/ under the same root and stamps the same key, so
# both modes below cover it.
#
# Modes (exactly one):
#   --under <dir>   delete folders whose WorkspacePath is inside <dir>. Called by
#                   cleanup-task-workspace.sh before it removes a worktree.
#   --orphans       delete folders whose WorkspacePath no longer exists. Called on a
#                   cadence by session-watchdog.js; catches crashes, hand-removed
#                   worktrees, and scratch builds outside the worktree root.
#
# Never touched: *.noindex (Xcode's shared caches), and any folder without an
# info.plist WorkspacePath (unknown owner). A folder whose workspace still exists is
# never deleted by --orphans, so an in-progress build is safe.
#
# Usage:
#   derived-data-reap.sh (--under <dir> | --orphans) [--dry-run] [--root <dd-root>]
#
# Output: one "REAP <folder> (<MB>MB) ws=<path>" line per deletion, then a summary.
# Exit codes: 0 = done (including nothing to reap), 2 = usage error

set -euo pipefail

ROOT="$HOME/Library/Developer/Xcode/DerivedData"
MODE=""
UNDER=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --under)   MODE=under; UNDER="${2:-}"; shift 2 ;;
    --orphans) MODE=orphans; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --root)    ROOT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$MODE" ]] || { echo "Usage: derived-data-reap.sh (--under <dir> | --orphans) [--dry-run]" >&2; exit 2; }
[[ "$MODE" != under || -n "$UNDER" ]] || { echo "--under needs a directory" >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo ">> derived-data-reap: no DerivedData root ($ROOT); nothing to do"; exit 0; }

# Normalize the --under prefix: resolve symlinks (/tmp → /private/tmp) when it still
# exists, strip a trailing slash, and match both spellings against WorkspacePath.
if [[ "$MODE" == under ]]; then
  UNDER="${UNDER%/}"
  UNDER_REAL="$UNDER"
  [[ -d "$UNDER" ]] && UNDER_REAL="$(cd "$UNDER" && pwd -P)"
fi

reaped=0
freed_mb=0
for dir in "$ROOT"/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  [[ "$name" == *.noindex ]] && continue
  # PlistBuddy prints "File Doesn't Exist, Will Create" to STDOUT for a missing plist.
  [[ -f "$dir/info.plist" ]] || continue
  ws="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$dir/info.plist" 2>/dev/null || true)"
  [[ -n "$ws" ]] || continue

  if [[ "$MODE" == under ]]; then
    [[ "$ws" == "$UNDER"/* || "$ws" == "$UNDER_REAL"/* ]] || continue
  else
    [[ -e "$ws" ]] && continue
  fi

  mb="$(du -sm "$dir" 2>/dev/null | cut -f1 || echo 0)"
  echo "REAP $name (${mb}MB) ws=$ws"
  if ! $DRY_RUN; then
    rm -rf -- "$dir" || echo ">> derived-data-reap: WARN could not fully remove $dir" >&2
  fi
  reaped=$((reaped + 1))
  freed_mb=$((freed_mb + ${mb:-0}))
done

verb=$([[ $DRY_RUN == true ]] && echo "would free" || echo "freed")
echo ">> derived-data-reap: mode=$MODE folders=$reaped $verb ~$((freed_mb / 1024))GB"
exit 0
