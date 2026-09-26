#!/usr/bin/env bash
# ensure-sim-pool.sh — Make the iOS-sim pool have N entries in "free" state.
#
# The pool is a small set of pre-cloned simulators waiting to be allocated to
# agent tasks. Allocate-from-pool returns one instantly (no clone wait).
# release-pool-entry marks one dirty when its task ends; this script refreshes
# dirty entries by deleting the stale sim and re-cloning from master.
#
# Per-entry state in pool.json:
#   free     — ready for allocation
#   in_use   — currently allocated to a task (do not touch)
#   dirty    — task is done; sim is stale; needs delete + re-clone
#   cloning  — a clone is in flight (cloning_since = epoch); not allocatable, not
#              re-cloned by a concurrent run. Older than CLONE_STALE_SEC with no
#              clone process alive is treated as dirty again.
#
# Two callers, two shapes:
#   launchd com.jontz.sim-pool-refresh (every 30 min): the FULL refresh. Runs
#     refresh-master-build.sh first (rebuilds the master when develop's native
#     side moved, marking not-in_use slots dirty), then reclones every dirty slot.
#   the spawn path (asana-watcher.js, resume-task.sh): SKIP_MASTER_REFRESH=1 and
#     --min-free <n>. Clones only until <n> slots are free, so a spawn never waits
#     on a master rebuild or on refilling slots it does not need.
#
# The pool lock is held only around pool.json read-modify-writes, never across a
# simctl clone, so a background refill and a spawn-path top-up can run at once;
# the cloning state is what keeps them off the same slot.
#
# Usage:
#   ensure-sim-pool.sh [--size N] [--min-free N] [--name-prefix <prefix>]
#
#   --size         pool size; default reads .watcher.sim_pool.size from
#                  asana-config.json, else .watcher.max_concurrent, else 2.
#   --min-free     stop recloning once this many slots are free (default: size,
#                  i.e. refresh everything dirty).
#   --name-prefix  sim name prefix; default "agent-sim-pool-".
#
# Behavior is idempotent. Re-running with a smaller --size shrinks the pool
# (deletes excess entries — but only if they're not in_use). in_use entries
# are NEVER deleted.
#
# Exit codes:
#   0 = at least --min-free entries are free; without --min-free, every slot
#       that is not in_use (or cloning elsewhere) is free
#   1 = short of that (a clone failed, or another run holds the remaining dirty
#       slots in cloning state)

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
CONFIG="$DIR/asana-config.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"; mkdir -p "$STATE_DIR"
POOL="$STATE_DIR/pool.json"
LOCK="$DIR/pool.lock"
CLONE_STALE_SEC=900

SIZE=""
MIN_FREE=""
PREFIX="agent-sim-pool-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)        SIZE="$2";     shift 2 ;;
    --min-free)    MIN_FREE="$2"; shift 2 ;;
    --name-prefix) PREFIX="$2";   shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Resolve size from config if not passed.
if [[ -z "$SIZE" ]]; then
  SIZE=$(jq -r '.watcher.sim_pool.size // .watcher.max_concurrent // 2' "$CONFIG")
fi
MIN_FREE_ARG="$MIN_FREE"
[[ -n "$MIN_FREE" ]] || MIN_FREE="$SIZE"
[[ "$MIN_FREE" -le "$SIZE" ]] || MIN_FREE="$SIZE"

log() { echo ">> ensure-sim-pool: $*" >&2; }

# Refresh the master sim's build from develop BEFORE the dirty→reclone loop below,
# so clones inherit a current-develop app instead of a stale one. When develop
# advanced with a native (Podfile.lock) change, refresh-master-build rebuilds the
# master and marks the not-in_use pool slots dirty, which the loop below then
# reclones from the fresh master in this same pass. BLOCKING and NON-FATAL: a
# fetch/build failure logs and returns 0 so provisioning continues on the
# last-good master. The spawn path sets SKIP_MASTER_REFRESH=1; only the launchd
# refresh job pays for the build.
if [[ "${SKIP_MASTER_REFRESH:-}" != "1" && -x "$DIR/refresh-master-build.sh" ]]; then
  "$DIR/refresh-master-build.sh" || log "master-build refresh exited $? (non-fatal; continuing on current master)"
fi

# Returns the task GID of a LIVE active session (claude-asana-<digits>) currently
# running on this sim UDID (its claude process exports AGENT_SIM_UDID), or empty.
# Used to RECLAIM (not recycle) a sim that got marked dirty but is still in active
# use — e.g. a resumed followup session. Retired (done-asana-*) sessions are
# intentionally NOT matched, so their sims remain recyclable.
sim_live_owner() {
  local want="$1" sess gid ppid cpid envudid
  while IFS= read -r sess; do
    gid="${sess#claude-asana-}"
    [[ "$gid" =~ ^[0-9]+$ ]] || continue
    ppid="$(tmux list-panes -t "$sess" -F '#{pane_pid}' 2>/dev/null | head -1)"
    [[ -n "$ppid" ]] || continue
    cpid="$(pgrep -P "$ppid" 2>/dev/null | head -1)"
    [[ -n "$cpid" ]] || continue
    envudid="$(ps eww -p "$cpid" 2>/dev/null | tr ' ' '\n' | sed -n 's/^AGENT_SIM_UDID=//p' | head -1)"
    if [[ "$envudid" == "$want" ]]; then echo "$gid"; return 0; fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-asana-')
  return 0
}

# ── pool.json access: every read-modify-write runs under the lock, and nothing
#    else does (a clone takes minutes; the lock must not outlive a jq call). ──
lock_pool() {
  local i=0
  while ! ( set -C; : > "$LOCK" ) 2>/dev/null; do
    i=$((i + 1))
    [[ $i -gt 300 ]] && { echo "Could not acquire $LOCK after 30s" >&2; exit 1; }
    sleep 0.1
  done
}
unlock_pool() { rm -f "$LOCK"; }
trap 'unlock_pool' EXIT
# pool_edit <jq filter> [jq args...]: rewrite pool.json through the filter, atomically.
pool_edit() {
  local filter="$1"; shift
  lock_pool
  local tmp; tmp=$(mktemp)
  jq "$@" "$filter" "$POOL" > "$tmp" && mv "$tmp" "$POOL"
  unlock_pool
}
slot_field() { jq -r --arg s "$1" ".pool[] | select(.slot == (\$s | tonumber)) | .$2" "$POOL"; }
count_state() { jq --arg st "$1" '[.pool[] | select(.state == $st)] | length' "$POOL"; }

# Initialize pool.json if missing.
if [[ ! -f "$POOL" ]]; then
  echo '{ "pool": [] }' > "$POOL"
fi

# Step 1: drop entries beyond requested SIZE if they are not in_use.
# (We never force-evict an in_use entry; assume the watcher will reap it later
# and the next run of ensure-sim-pool will catch up.)
EXISTING_COUNT=$(jq '.pool | length' "$POOL")
if [[ "$EXISTING_COUNT" -gt "$SIZE" ]]; then
  for (( i = EXISTING_COUNT - 1; i >= SIZE; i-- )); do
    STATE=$(jq -r ".pool[$i].state" "$POOL")
    UDID=$(jq -r ".pool[$i].udid" "$POOL")
    if [[ "$STATE" == "in_use" || "$STATE" == "cloning" ]]; then
      log "slot $i is $STATE; skipping shrink"
      continue
    fi
    if [[ -n "$UDID" && "$UDID" != "null" ]]; then
      log "shrinking: deleting sim $UDID (slot $i, state $STATE)"
      "$DIR/delete-ios-sim.sh" --udid "$UDID" 2>&1 | sed 's/^/   /' >&2 || true
    fi
    pool_edit "del(.pool[$i])"
  done
fi

# Step 2: ensure each slot 0..SIZE-1 has an entry.
for (( slot = 0; slot < SIZE; slot++ )); do
  PRESENT=$(slot_field "$slot" slot | head -1)
  if [[ -z "$PRESENT" ]]; then
    log "slot $slot missing — appending placeholder"
    pool_edit ".pool += [{slot: $slot, udid: null, state: \"dirty\"}]"
  fi
done

# Step 3: refresh dirty slots (delete stale sim, clone fresh) until MIN_FREE are free.
# A slot is claimed as "cloning" under the lock before the clone starts, so a
# concurrent run leaves it alone; the clone itself runs unlocked.
CLONE_FAILED=0
NOW=$(date +%s)
for (( slot = 0; slot < SIZE; slot++ )); do
  FREE=$(count_state free)
  if [[ "$FREE" -ge "$MIN_FREE" ]]; then
    break
  fi
  STATE=$(slot_field "$slot" state)
  UDID=$(slot_field "$slot" udid)
  NAME="${PREFIX}${slot}"

  if [[ "$STATE" == "cloning" ]]; then
    SINCE=$(slot_field "$slot" cloning_since); [[ "$SINCE" =~ ^[0-9]+$ ]] || SINCE=0
    if (( NOW - SINCE < CLONE_STALE_SEC )) || pgrep -f "clone-ios-sim.sh --name $NAME\$" >/dev/null 2>&1; then
      log "slot $slot — clone in flight elsewhere; leaving it"
      continue
    fi
    log "slot $slot — stale cloning marker ($(( NOW - SINCE ))s, no clone process); treating as dirty"
    STATE="dirty"
  fi
  [[ "$STATE" == "dirty" ]] || continue

  # Guard: never recycle a sim a LIVE active session is still running on (a dirty
  # entry whose UDID is in a claude-asana-<digits> session's env — e.g. a resumed
  # followup). Reclaim it as in_use instead of deleting it out from under the agent.
  if [[ -n "$UDID" && "$UDID" != "null" ]]; then
    OWNER="$(sim_live_owner "$UDID")"
    if [[ -n "$OWNER" ]]; then
      log "slot $slot dirty but sim $UDID is IN USE by live session claude-asana-$OWNER → reclaiming (not recycling)"
      pool_edit '(.pool[] | select(.slot == ($s | tonumber))) |= (.state = "in_use" | .task_gid = $g)' --arg s "$slot" --arg g "$OWNER"
      continue
    fi
  fi

  pool_edit '(.pool[] | select(.slot == ($s | tonumber))) |= (.state = "cloning" | .cloning_since = ($t | tonumber))' --arg s "$slot" --arg t "$NOW"

  if [[ -n "$UDID" && "$UDID" != "null" ]]; then
    log "slot $slot dirty — deleting stale sim $UDID"
    "$DIR/delete-ios-sim.sh" --udid "$UDID" 2>&1 | sed 's/^/   /' >&2 || true
  fi

  log "slot $slot — cloning fresh sim '$NAME'"
  NEW_UDID=""
  if NEW_UDID=$("$DIR/clone-ios-sim.sh" --name "$NAME" 2>&1 | tee /dev/stderr | tail -1) && [[ "$NEW_UDID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    # If refresh-master-build marked this slot dirty while the clone ran, the new
    # sim already carries the old master: keep it dirty (with its udid, so the
    # next pass deletes it) instead of publishing it as free.
    pool_edit '(.pool[] | select(.slot == ($s | tonumber))) |= (.udid = $u | del(.cloning_since) | .state = (if .state == "cloning" then "free" else .state end))' --arg s "$slot" --arg u "$NEW_UDID"
    log "slot $slot — $(slot_field "$slot" state) ($NEW_UDID)"
  else
    log "slot $slot — clone failed or produced no UDID; leaving dirty"
    pool_edit '(.pool[] | select(.slot == ($s | tonumber))) |= (.state = "dirty" | del(.cloning_since))' --arg s "$slot"
    CLONE_FAILED=1
  fi
done

# Summary
FREE=$(count_state free)
INUSE=$(count_state in_use)
DIRTY=$(count_state dirty)
CLONING=$(count_state cloning)
# A full refresh (no --min-free) cannot free in_use slots; its target is "nothing
# left dirty", so the launchd job exits 0 while runs hold sims.
[[ -n "$MIN_FREE_ARG" ]] || MIN_FREE=$(( SIZE - INUSE - CLONING ))
log "pool ready: free=$FREE in_use=$INUSE dirty=$DIRTY cloning=$CLONING (size=$SIZE, wanted free>=$MIN_FREE)"
[[ "$FREE" -ge "$MIN_FREE" ]] && exit 0
[[ "$CLONE_FAILED" -eq 1 ]] && log "a clone failed; fewer than $MIN_FREE free"
exit 1
