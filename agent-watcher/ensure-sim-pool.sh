#!/usr/bin/env bash
# ensure-sim-pool.sh — Make the iOS-sim pool have N entries in "free" state.
#
# The pool is a small set of pre-cloned simulators waiting to be allocated to
# agent tasks. Allocate-from-pool returns one instantly (no clone wait).
# release-pool-entry marks one dirty when its task ends; this script refreshes
# dirty entries by deleting the stale sim and re-cloning from master.
#
# Per-entry state in pool.json:
#   free    — ready for allocation
#   in_use  — currently allocated to a task (do not touch)
#   dirty   — task is done; sim is stale; needs delete + re-clone
#
# Usage:
#   ensure-sim-pool.sh [--size N] [--name-prefix <prefix>]
#
#   --size         pool size; default reads .watcher.sim_pool.size from
#                  asana-config.json, else .watcher.max_concurrent, else 2.
#   --name-prefix  sim name prefix; default "agent-sim-pool-".
#
# Behavior is idempotent. Re-running with a smaller --size shrinks the pool
# (deletes excess entries — but only if they're not in_use). in_use entries
# are NEVER deleted.
#
# Exit codes:
#   0 = pool is ready (all entries free, or at least all not-in_use entries are free)
#   1 = a clone operation failed (pool may be partially filled)

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
CONFIG="$DIR/asana-config.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"; mkdir -p "$STATE_DIR"
POOL="$STATE_DIR/pool.json"
LOCK="$DIR/pool.lock"

SIZE=""
PREFIX="agent-sim-pool-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)        SIZE="$2";   shift 2 ;;
    --name-prefix) PREFIX="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Resolve size from config if not passed.
if [[ -z "$SIZE" ]]; then
  SIZE=$(jq -r '.watcher.sim_pool.size // .watcher.max_concurrent // 2' "$CONFIG")
fi

log() { echo ">> ensure-sim-pool: $*" >&2; }

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

# Atomic JSON update via lock + tmpfile.
acquire_lock() {
  local i=0
  while ! ( set -C; : > "$LOCK" ) 2>/dev/null; do
    i=$((i + 1))
    [[ $i -gt 300 ]] && { echo "Could not acquire $LOCK after 30s" >&2; exit 1; }
    sleep 0.1
  done
  trap 'rm -f "$LOCK"' EXIT
}
write_pool() {
  local tmp; tmp=$(mktemp)
  jq . > "$tmp" <<<"$1"
  mv "$tmp" "$POOL"
}

# Initialize pool.json if missing.
if [[ ! -f "$POOL" ]]; then
  echo '{ "pool": [] }' > "$POOL"
fi

acquire_lock

POOL_JSON=$(cat "$POOL")

# Step 1: drop entries beyond requested SIZE if they are not in_use.
# (We never force-evict an in_use entry; assume the watcher will reap it later
# and the next run of ensure-sim-pool will catch up.)
EXISTING_COUNT=$(jq '.pool | length' <<<"$POOL_JSON")
if [[ "$EXISTING_COUNT" -gt "$SIZE" ]]; then
  for (( i = EXISTING_COUNT - 1; i >= SIZE; i-- )); do
    STATE=$(jq -r ".pool[$i].state" <<<"$POOL_JSON")
    UDID=$(jq -r ".pool[$i].udid" <<<"$POOL_JSON")
    if [[ "$STATE" == "in_use" ]]; then
      log "slot $i is in_use; skipping shrink"
      continue
    fi
    if [[ -n "$UDID" && "$UDID" != "null" ]]; then
      log "shrinking: deleting sim $UDID (slot $i, state $STATE)"
      "$DIR/delete-ios-sim.sh" --udid "$UDID" 2>&1 | sed 's/^/   /' >&2 || true
    fi
    POOL_JSON=$(jq "del(.pool[$i])" <<<"$POOL_JSON")
  done
  write_pool "$POOL_JSON"
fi

# Step 2: ensure each slot 0..SIZE-1 has an entry.
for (( slot = 0; slot < SIZE; slot++ )); do
  PRESENT=$(jq -r ".pool[] | select(.slot == $slot) | .slot" <<<"$POOL_JSON" | head -1)
  if [[ -z "$PRESENT" ]]; then
    log "slot $slot missing — appending placeholder"
    POOL_JSON=$(jq ".pool += [{slot: $slot, udid: null, state: \"dirty\"}]" <<<"$POOL_JSON")
  fi
done
write_pool "$POOL_JSON"

# Step 3: refresh anything in state=dirty (delete stale sim, clone fresh).
# Iterate via slot indices so we can rewrite the JSON between clones.
for (( slot = 0; slot < SIZE; slot++ )); do
  POOL_JSON=$(cat "$POOL")
  STATE=$(jq -r ".pool[] | select(.slot == $slot) | .state" <<<"$POOL_JSON")
  UDID=$(jq -r ".pool[] | select(.slot == $slot) | .udid" <<<"$POOL_JSON")
  NAME="${PREFIX}${slot}"

  if [[ "$STATE" != "dirty" ]]; then
    continue
  fi

  # Guard: never recycle a sim a LIVE active session is still running on (a dirty
  # entry whose UDID is in a claude-asana-<digits> session's env — e.g. a resumed
  # followup). Reclaim it as in_use instead of deleting it out from under the agent.
  if [[ -n "$UDID" && "$UDID" != "null" ]]; then
    OWNER="$(sim_live_owner "$UDID")"
    if [[ -n "$OWNER" ]]; then
      log "slot $slot dirty but sim $UDID is IN USE by live session claude-asana-$OWNER → reclaiming (not recycling)"
      POOL_JSON=$(jq --arg s "$slot" --arg g "$OWNER" \
        '(.pool[] | select(.slot == ($s | tonumber))) |= (.state = "in_use" | .task_gid = $g)' <<<"$POOL_JSON")
      write_pool "$POOL_JSON"
      continue
    fi
    log "slot $slot dirty — deleting stale sim $UDID"
    "$DIR/delete-ios-sim.sh" --udid "$UDID" 2>&1 | sed 's/^/   /' >&2 || true
  fi

  log "slot $slot — cloning fresh sim '$NAME'"
  if NEW_UDID=$("$DIR/clone-ios-sim.sh" --name "$NAME" 2>&1 | tee /dev/stderr | tail -1); then
    if [[ "$NEW_UDID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
      POOL_JSON=$(jq --arg s "$slot" --arg u "$NEW_UDID" \
        '(.pool[] | select(.slot == ($s | tonumber)).udid) = $u
         | (.pool[] | select(.slot == ($s | tonumber)).state) = "free"' <<<"$POOL_JSON")
      write_pool "$POOL_JSON"
      log "slot $slot — free ($NEW_UDID)"
    else
      log "slot $slot — clone produced no UDID; leaving dirty"
      exit 1
    fi
  else
    log "slot $slot — clone failed; leaving dirty"
    exit 1
  fi
done

# Step 4: ensure orphan slots (no entry but in expected range) get filled.
# This catches the case where step 2 added a placeholder but step 3 already ran
# past it — should not happen but is cheap to guard against.
for (( slot = 0; slot < SIZE; slot++ )); do
  POOL_JSON=$(cat "$POOL")
  STATE=$(jq -r ".pool[] | select(.slot == $slot) | .state" <<<"$POOL_JSON")
  UDID=$(jq -r ".pool[] | select(.slot == $slot) | .udid" <<<"$POOL_JSON")
  if [[ "$STATE" == "free" && "$UDID" != "null" && -n "$UDID" ]]; then
    continue
  fi
  if [[ "$STATE" == "in_use" ]]; then
    continue
  fi
  log "slot $slot still not free — re-running refresh"
  POOL_JSON=$(jq --arg s "$slot" '(.pool[] | select(.slot == ($s | tonumber)).state) = "dirty"' <<<"$POOL_JSON")
  write_pool "$POOL_JSON"
  exec "$0" --size "$SIZE" --name-prefix "$PREFIX"
done

# Summary
FREE=$(jq '[.pool[] | select(.state == "free")] | length' "$POOL")
INUSE=$(jq '[.pool[] | select(.state == "in_use")] | length' "$POOL")
DIRTY=$(jq '[.pool[] | select(.state == "dirty")] | length' "$POOL")
log "pool ready: free=$FREE in_use=$INUSE dirty=$DIRTY (size=$SIZE)"
