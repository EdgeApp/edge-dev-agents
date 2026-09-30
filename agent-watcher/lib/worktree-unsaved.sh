#!/usr/bin/env bash
# worktree-unsaved.sh: does this task worktree hold work that exists nowhere else?
# Called by:
#   session-watchdog.js   pruneSessionlessWorktrees() spares every "unsaved" worktree
#   gc-worktrees.sh       the manual reaper spares the same worktrees
#
# UNSAVED = any of:
#   - a commit on HEAD that no remote-tracking ref reaches (never pushed);
#   - a modified, staged, or deleted tracked file;
#   - an untracked, non-ignored file (a new file the agent never committed).
# Build noise that every run produces is not work and is ignored:
#   - ios/Podfile.lock modified (pod install rewrites the hermes-engine checksum);
#   - .watchman-cookie-* (watchman scratch files in the repo root).
#
# A directory git cannot read (not a worktree, broken registration) reports
# "clean": the watchdog force-removes such leftovers, as it always has.
#
# Usage:   worktree-unsaved.sh <worktree-dir>
# Output:  exactly one line, "unsaved unpushed=<n> changed=<n>" or "clean"
# Exit:    0 = verdict printed, 1 = usage error

set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: worktree-unsaved.sh <worktree-dir>" >&2; exit 1; }
WT="$1"

if ! git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo clean
  exit 0
fi

UNPUSHED="$(git -C "$WT" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
CHANGED="$(git -C "$WT" status --porcelain 2>/dev/null \
  | grep -vE '^ M ios/Podfile\.lock$' \
  | grep -vE '^\?\? \.watchman-cookie-' \
  | wc -l | tr -d ' ' || true)"

if [[ "$UNPUSHED" -gt 0 || "$CHANGED" -gt 0 ]]; then
  echo "unsaved unpushed=$UNPUSHED changed=$CHANGED"
else
  echo clean
fi
