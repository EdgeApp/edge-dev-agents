#!/usr/bin/env bash
# gc-worktrees.sh — Manual garbage-collector for orphaned agent worktrees.
#
# Scans ~/git/.agent-worktrees/<gid>/<repo>/ and, for each, asks Asana what the
# task's agent_status is. A worktree is an ORPHAN candidate when:
#   - the task's agent_status is "Complete", OR
#   - the task no longer exists (deleted in Asana).
# In-flight tasks (Planning/Developing/Reviewing/Testing) are always left alone.
#
# RETENTION CAP: orphan candidates are NOT all reaped. The newest --keep of them
# (by worktree mtime) are retained for inspection/resume; only the older ones are
# reaped. This mirrors the rc-watchdog retention policy so a manual run won't
# silently destroy worktrees the watchdog is deliberately keeping. --keep defaults
# to .watcher.keep_completed_worktrees from asana-config.json (fallback 5). Pass
# --all to reap every orphan (keep=0, the pre-retention behavior).
#
# Teardown reuses cleanup-task-workspace.sh (worktree+branch) and, when slots.json
# still holds the slot, delete-ios-sim.sh (sim) + slots.js release (slot entry).
#
# This is NOT on launchd — run it by hand when you suspect leaked worktrees
# (e.g. after a crash or reboot left sessions half-cleaned).
#
# Usage:
#   gc-worktrees.sh [--dry-run] [--keep N | --all]
#
# Exit codes:
#   0 = scan complete (orphans removed, or none found)
#   1 = error (missing config/credentials)
#   2 = usage error

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
WORKTREES_ROOT="$HOME/git/.agent-worktrees"
CONFIG="$DIR/asana-config.json"
CRED="$DIR/credentials.json"

DRY_RUN=false
KEEP=""   # empty → resolve from config below; --keep N overrides; --all sets 0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --keep)    KEEP="$2";    shift 2 ;;
    --all)     KEEP=0;       shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$CONFIG" && -f "$CRED" ]] || { echo "Missing $CONFIG or $CRED" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

if [[ ! -d "$WORKTREES_ROOT" ]]; then
  echo ">> gc-worktrees: no worktrees root ($WORKTREES_ROOT) — nothing to do"
  exit 0
fi

TOKEN=$(jq -r .asana_token "$CRED")
FIELD_GID=$(jq -r .custom_fields.agent_status.gid "$CONFIG")

# Resolve the retention cap (newest N orphans kept). Default from config, fallback 5.
if [[ -z "$KEEP" ]]; then
  KEEP=$(jq -r '.watcher.keep_completed_worktrees // 5' "$CONFIG")
fi
[[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "Invalid --keep value: $KEEP" >&2; exit 2; }

# Returns the agent_status name, or "__MISSING__" if the task 404s, or "" on error.
fetch_status() {
  local gid="$1"
  local resp
  resp=$(curl -sS -H "Authorization: Bearer $TOKEN" \
    "https://app.asana.com/api/1.0/tasks/$gid?opt_fields=custom_fields.gid,custom_fields.enum_value.name" 2>/dev/null || echo '')
  [[ -z "$resp" ]] && { echo ""; return; }
  if echo "$resp" | jq -e '.errors[]? | select(.message | test("Not a recognized ID|does not exist"; "i"))' >/dev/null 2>&1; then
    echo "__MISSING__"; return
  fi
  echo "$resp" | jq -r --arg f "$FIELD_GID" '.data.custom_fields[]? | select(.gid==$f) | .enum_value.name // ""'
}

# Pass 1: classify every worktree. In-flight ones are left alone immediately.
# Complete/missing ones are orphan candidates, collected with their mtime so we
# can retain the newest $KEEP and reap only the rest.
ORPHANS=()   # entries: "<mtime>\t<gid>\t<repo>\t<reason>"
kept_inflight=0
for giddir in "$WORKTREES_ROOT"/*/; do
  [[ -d "$giddir" ]] || continue
  gid=$(basename "$giddir")
  for repodir in "$giddir"*/; do
    [[ -d "$repodir" ]] || continue
    repo=$(basename "$repodir")
    status=$(fetch_status "$gid")

    if [[ "$status" == "Complete" || "$status" == "__MISSING__" ]]; then
      reason=$([[ "$status" == "__MISSING__" ]] && echo "task-deleted" || echo "Complete")
      mtime=$(stat -f "%m" "$repodir")
      ORPHANS+=("${mtime}"$'\t'"${gid}"$'\t'"${repo}"$'\t'"${reason}")
    else
      echo ">> gc-worktrees: keep $gid/$repo (in-flight: agent_status=${status:-unknown})"
      kept_inflight=$((kept_inflight + 1))
    fi
  done
done

# Pass 2: newest $KEEP orphans are retained; the rest are reaped (oldest first).
removed=0
retained=0
if [[ ${#ORPHANS[@]} -gt 0 ]]; then
  idx=0
  while IFS=$'\t' read -r _mtime gid repo reason; do
    if [[ $idx -lt $KEEP ]]; then
      echo ">> gc-worktrees: retain $gid/$repo ($reason; within keep=$KEEP)"
      retained=$((retained + 1))
    else
      echo ">> gc-worktrees: REAP $gid/$repo ($reason; beyond keep=$KEEP)"
      if ! $DRY_RUN; then
        # Tear down sim from the slot record (if any) before dropping the slot.
        sim_udid=$(node "$DIR/lib/slots.js" get --task-gid "$gid" 2>/dev/null | jq -r '.sim_udid // empty' 2>/dev/null || true)
        [[ -n "$sim_udid" ]] && "$DIR/delete-ios-sim.sh" --udid "$sim_udid" || true
        "$DIR/cleanup-task-workspace.sh" --task-gid "$gid" --repo "$repo" || true
        node "$DIR/lib/slots.js" release --task-gid "$gid" >/dev/null 2>&1 || true
      fi
      removed=$((removed + 1))
    fi
    idx=$((idx + 1))
  done < <(printf '%s\n' "${ORPHANS[@]}" | sort -rn -t$'\t' -k1,1)
fi

echo ">> gc-worktrees: done — keep=$KEEP, ${retained} completed worktree(s) retained, ${removed} $([[ $DRY_RUN == true ]] && echo "would be reaped" || echo "reaped"), ${kept_inflight} in-flight kept"
exit 0
