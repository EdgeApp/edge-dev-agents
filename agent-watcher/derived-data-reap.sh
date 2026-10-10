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
# Modes (--under alone, or --orphans and/or --stale-hours together):
#   --under <dir>   delete folders whose WorkspacePath is inside <dir>. Called by
#                   cleanup-task-workspace.sh before it removes a worktree.
#   --orphans       delete folders whose WorkspacePath no longer exists. Called on a
#                   cadence by session-watchdog.js; catches crashes, hand-removed
#                   worktrees, and scratch builds outside the worktree root.
#   --stale-hours <n>
#                   delete folders whose workspace STILL exists but which nothing has
#                   built into for <n> hours. A finished run's worktree is retained
#                   for followups, often for weeks, and its ~5.5 GB of build output is
#                   only worth keeping while a rebuild in that worktree is likely:
#                   an incremental rebuild takes 2-3 minutes against 12-15 cold, so
#                   the folder stays through same-day review rounds and goes after.
#                   Limited to workspaces under an agent root (--agent-root, default
#                   the watcher's worktrees root and ~/git/.agent-shadows), so the
#                   primary checkouts (the master build's incremental cache) and any
#                   hand-opened project are never touched, and never a workspace
#                   inside a worktree that slots.json lists as in use. Same cadence
#                   and caller as --orphans.
#
# Never touched: *.noindex (Xcode's shared caches), and any folder without an
# info.plist WorkspacePath (unknown owner). A folder whose workspace still exists is
# never deleted by --orphans, so an in-progress build is safe. --stale-hours reads
# "last built" as the newer of the folder's and its info.plist's mtime: Xcode
# rewrites info.plist (LastAccessedDate) on every build.
#
# Usage:
#   derived-data-reap.sh (--under <dir> | [--orphans] [--stale-hours <n>]) [--dry-run]
#                        [--root <dd-root>] [--agent-root <dir>]... [--slots <slots.json>]
#
# Output: one "REAP <folder> (<MB>MB) ws=<path>" line per deletion, then a summary.
# Exit codes: 0 = done (including nothing to reap), 2 = usage error

set -euo pipefail

ROOT="$HOME/Library/Developer/Xcode/DerivedData"
MODE=""
UNDER=""
ORPHANS=false
STALE_HOURS=""
AGENT_ROOTS=()
SLOTS="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/slots.json"
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --under)       MODE=under; UNDER="${2:-}"; shift 2 ;;
    --orphans)     ORPHANS=true; shift ;;
    --stale-hours) STALE_HOURS="${2:-}"; shift 2 ;;
    --agent-root)  AGENT_ROOTS+=("${2%/}"); shift 2 ;;
    --slots)       SLOTS="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --root)        ROOT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
USAGE="Usage: derived-data-reap.sh (--under <dir> | [--orphans] [--stale-hours <n>]) [--dry-run]"
if [[ "$MODE" == under ]]; then
  [[ -n "$UNDER" ]] || { echo "--under needs a directory" >&2; exit 2; }
  { ! $ORPHANS && [[ -z "$STALE_HOURS" ]]; } || { echo "--under cannot be combined with another mode" >&2; exit 2; }
else
  { $ORPHANS || [[ -n "$STALE_HOURS" ]]; } || { echo "$USAGE" >&2; exit 2; }
  case "$STALE_HOURS" in *[!0-9]*) echo "--stale-hours takes whole hours" >&2; exit 2 ;; esac
  # The summary line's label only; the loop below keys on ORPHANS and STALE_HOURS.
  $ORPHANS && MODE="orphans"
  [[ -n "$STALE_HOURS" ]] && MODE="${MODE:+$MODE+}stale${STALE_HOURS}h"
fi
[[ -d "$ROOT" ]] || { echo ">> derived-data-reap: no DerivedData root ($ROOT); nothing to do"; exit 0; }

# Normalize the --under prefix: resolve symlinks (/tmp → /private/tmp) when it still
# exists, strip a trailing slash, and match both spellings against WorkspacePath.
if [[ "$MODE" == under ]]; then
  UNDER="${UNDER%/}"
  UNDER_REAL="$UNDER"
  [[ -d "$UNDER" ]] && UNDER_REAL="$(cd "$UNDER" && pwd -P)"
fi

# --stale-hours scope: the agent roots, and the worktrees a live run holds.
if [[ -n "$STALE_HOURS" ]]; then
  if [[ ${#AGENT_ROOTS[@]} -eq 0 ]]; then
    wr="$(jq -r '.watcher.worktrees_root // empty' "$HOME/.config/agent-watcher/asana-config.json" 2>/dev/null || true)"
    wr="${wr/#\~/$HOME}"
    AGENT_ROOTS=("${wr:-$HOME/git/.agent-worktrees}" "$HOME/git/.agent-shadows")
  fi
  IN_USE="$(jq -r '.slots[]?.worktree_path // empty' "$SLOTS" 2>/dev/null || true)"
  NOW="$(date +%s)"
fi
# True when <ws> may be reaped as stale: under an agent root, not inside an in-use
# worktree, and <dir> unbuilt for STALE_HOURS.
stale_ok() {
  local ws="$1" dir="$2" r ok="" w m1 m2
  for r in "${AGENT_ROOTS[@]}"; do [[ "$ws" == "$r"/* ]] && ok=1; done
  [[ -n "$ok" ]] || return 1
  while IFS= read -r w; do
    [[ -n "$w" && "$ws" == "${w%/}"/* ]] && return 1
  done <<< "$IN_USE"
  m1="$(stat -f %m "$dir" 2>/dev/null || echo "$NOW")"
  m2="$(stat -f %m "$dir/info.plist" 2>/dev/null || echo "$NOW")"
  [[ "$m2" -gt "$m1" ]] && m1="$m2"
  [[ $(( (NOW - m1) / 3600 )) -ge "$STALE_HOURS" ]]
}

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
  elif [[ ! -e "$ws" ]]; then
    $ORPHANS || continue
  else
    [[ -n "$STALE_HOURS" ]] && stale_ok "$ws" "$dir" || continue
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
