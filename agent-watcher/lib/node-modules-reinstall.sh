#!/usr/bin/env bash
# node-modules-reinstall.sh: make <dir>/node_modules match <dir>/package-lock.json.
#
# Usage: node-modules-reinstall.sh <repo-dir>
#
# Steps: no-op when the normalized hashes already match (lib/node-modules-freshness.sh);
# otherwise take the machine-wide install lock, move node_modules ASIDE (a rename
# into a trash dir on the same volume), run `sfw npm ci` (plain `npm ci` when sfw
# is absent), and delete the old tree in the background. Moving aside is required:
# npm ci over an APFS-cloned tree fails ENOTEMPTY (rmdir -66), and so does rm -rf.
# On failure (or SIGINT/SIGTERM) the partial tree goes to trash and the previous
# tree is moved back, so the repo is never left worse than before the attempt;
# the .stale-node-modules marker records status=failed and the log path.
# On success the marker is removed once the hashes match.
#
# Callers: setup-task-workspace.sh (detached, bounded wait), refresh-main-checkouts.sh
# (foreground), and agents fixing a marker by hand.
#
# Env: NM_NO_MARKER=1 (do not create .stale-node-modules; an existing one is still updated),
#      NM_LOCK_WAIT (seconds to wait for the install lock, default 1800),
#      NODE_MODULES_TRASH (trash dir; default ~/git/.node-modules-trash when on
#      the same volume as <dir>, else <dir>/../.node-modules-trash).
# Exit: 0 = fresh (already, or after install); 1 = install failed / lock timeout;
#       2 = usage or not applicable (no package-lock.json).
set -uo pipefail
source "$HOME/.config/agent-watcher/lib/launchd-env.sh" 2>/dev/null || true
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/node-modules-freshness.sh"

DIR="${1:-}"
[[ -n "$DIR" && -d "$DIR" ]] || { echo "Usage: node-modules-reinstall.sh <repo-dir>" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"
NAME="$(basename "$DIR")"
LOG="${TMPDIR:-/tmp}"; LOG="${LOG%/}/node-modules-reinstall-$NAME-$$.log"

rc=0; nm_hashes "$DIR" || rc=$?
if [[ "$rc" -eq 2 ]]; then
  echo ">> node-modules-reinstall: $DIR has no usable package-lock.json; nothing to do" >&2
  exit 2
fi
if [[ "$rc" -eq 0 ]]; then
  rm -f "$(nm_marker_path "$DIR")"
  echo ">> node-modules-reinstall: $NAME already fresh ($NM_WANT)" >&2
  exit 0
fi

# Record ourselves so readers (ios-rn-build, install-deps) wait instead of racing.
# NM_NO_MARKER=1 (refresh-main-checkouts: a marker file would make the main
# checkout dirty and hold every later sweep) skips creating one.
[[ -f "$(nm_marker_path "$DIR")" || -n "${NM_NO_MARKER:-}" ]] || nm_marker_write "$DIR" "node-modules-reinstall"
nm_marker_set "$DIR" installer_pid "$$"
nm_marker_set "$DIR" installer_log "$LOG"
nm_marker_set "$DIR" status installing

trash_root="${NODE_MODULES_TRASH:-}"
if [[ -z "$trash_root" ]]; then
  trash_root="$HOME/git/.node-modules-trash"
  mkdir -p "$trash_root" 2>/dev/null || true
  if [[ "$(stat -f %d "$trash_root" 2>/dev/null)" != "$(stat -f %d "$DIR" 2>/dev/null)" ]]; then
    trash_root="$(dirname "$DIR")/.node-modules-trash"
  fi
fi
mkdir -p "$trash_root"
# Reap trees an earlier background delete never finished (reboot, kill).
( find "$trash_root" -mindepth 1 -maxdepth 1 -mmin +120 -exec rm -rf {} + >/dev/null 2>&1 & )
ASIDE="$trash_root/$NAME.$$.$(date +%s)"
MOVED=false
DONE=false

bg_delete() { [[ -e "$1" ]] && nohup rm -rf "$1" >/dev/null 2>&1 & }

restore() {
  $MOVED || return 0
  if [[ -e "$DIR/node_modules" ]]; then
    mv "$DIR/node_modules" "$ASIDE.partial" 2>/dev/null && bg_delete "$ASIDE.partial"
  fi
  mv "$ASIDE" "$DIR/node_modules" 2>/dev/null && MOVED=false
}
on_exit() {
  $DONE || { restore; nm_marker_set "$DIR" status failed; }
  nm_marker_set "$DIR" installer_pid ""
  nm_install_lock_release
}
trap on_exit EXIT
trap 'exit 1' INT TERM HUP

echo ">> node-modules-reinstall: $NAME stale (want $NM_WANT, have $NM_HAVE); waiting for the install lock" >&2
if ! nm_install_lock_acquire "${NM_LOCK_WAIT:-1800}"; then
  echo ">> node-modules-reinstall: FAIL, install lock busy past ${NM_LOCK_WAIT:-1800}s; marker kept" >&2
  nm_marker_set "$DIR" status lock-timeout
  DONE=true
  exit 1
fi

# Another installer may have fixed it while we waited.
rc=0; nm_hashes "$DIR" || rc=$?
if [[ "$rc" -eq 0 ]]; then
  DONE=true
  rm -f "$(nm_marker_path "$DIR")"
  echo ">> node-modules-reinstall: $NAME became fresh while waiting ($NM_WANT)" >&2
  exit 0
fi

if [[ -e "$DIR/node_modules" ]]; then
  mv "$DIR/node_modules" "$ASIDE" || { echo ">> node-modules-reinstall: FAIL, could not move node_modules aside" >&2; exit 1; }
  MOVED=true
fi

# Run the REAL npm through sfw: strip the agent npm shim (it execs sfw itself).
CI_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$HOME/.agent-shims" | paste -sd ':' -)"
if PATH="$CI_PATH" command -v sfw >/dev/null 2>&1; then CI=(sfw npm ci --no-audit --no-fund); else CI=(npm ci --no-audit --no-fund); fi
t0=$(date +%s)
echo ">> node-modules-reinstall: ${CI[*]} in $DIR (log $LOG)" >&2
if (cd "$DIR" && PATH="$CI_PATH" "${CI[@]}") >"$LOG" 2>&1; then
  DONE=true
  MOVED=false
  bg_delete "$ASIDE"
  rc=0; nm_hashes "$DIR" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$(nm_marker_path "$DIR")"
    echo ">> node-modules-reinstall: OK in $(( $(date +%s) - t0 ))s; $NAME fresh ($NM_WANT)" >&2
    exit 0
  fi
  nm_marker_set "$DIR" have "$NM_HAVE"
  nm_marker_set "$DIR" status installed-still-mismatched
  echo ">> node-modules-reinstall: WARN, npm ci succeeded but hashes differ (want $NM_WANT, have $NM_HAVE); marker kept" >&2
  exit 1
fi
echo ">> node-modules-reinstall: FAIL, ${CI[*]} exited non-zero after $(( $(date +%s) - t0 ))s; previous tree restored, marker kept. Last log lines:" >&2
tail -15 "$LOG" >&2
exit 1
